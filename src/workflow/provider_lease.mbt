///| Global provider admission: who may hold a provider surface right now.
///
/// `maximum_parallel_parts` bounds one Goal's own concurrency. It says nothing
/// about the portfolio, so two Goals that each respect it can still ask Claude
/// or Codex for more sessions than the subscription serves. This file is the
/// portfolio-wide bound: before a Goal may admit new provider work it has to
/// hold a lease on the surface that work will run on.
///
/// Scope, precisely, because it used to be narrower than the claim: both
/// provider dispatches a Goal makes are leased, from two call sites in
/// `src/exec/goal_execution_native.mbt`. Part implementation, verification,
/// repair, and audit work is leased at `native_goal_effect_authorization`, which
/// is what `goal_authorizes_new_effects` is bound to. The Goal's own audit
/// session — planned, dispatched, and reconciled by `advance_native_goal_assurance`,
/// which never passes that seam — is leased at
/// `native_goal_assurance_effect_admission` instead, keyed by
/// `goal_assurance_provider_lease_id` rather than by a Part it does not have.
/// Both call `acquire_provider_lease` below, so there is one held set and one
/// bound rather than two. Goal *verification* takes no lease: it runs declared
/// commands in a sandbox and reaches no provider surface.
///
/// Both paths lease the retry as well as the first attempt, which is the half
/// that is easy to lose. An effect a dying pass left `PartEffectMayHaveOccurred`
/// is re-executed by a later pass that authorizes nothing, and no slot is held
/// for it by then: the first pass either returned it — `release_after_part_pass`
/// for a Part, `finish_native_goal_assurance_leases` for the Goal audit — or
/// died and had it reclaimed with its generation by the rule below. The
/// process the first dispatch may have started is gone, which is why the
/// reconciler asks for a retry at all, so the retried session is a new session
/// on the surface. `drive_part_workflow` therefore re-enters
/// `goal_authorizes_new_effects` before re-executing a provider dispatch, and
/// `advance_native_goal_assurance` puts its admission ahead of the whole
/// `pending_effect` match rather than inside the authorize arm. Retries of
/// effects that reach no provider stay unleased: they spend no allowance, and
/// a pass that goes on to do anything else takes the slot at its next planning
/// step.
///
/// Provider surfaces are the only capacity dimension here, and sandbox count is
/// deliberately not a second one. A Take's box is a fixed shape — 2 vCPU,
/// 2048 MiB, 4 GiB, pinned into `@sandbox.boxlite_take_runtime_policy_digest` —
/// so a count would be a linear proxy for host memory, but there is no host
/// budget anywhere to derive the number from, and an invented default is either
/// a stranded workstation or an out-of-memory CI box. That is the whole of the
/// reason, and it deliberately does not lean on the lease: a lease bounds
/// provider sessions, not boxes, and boxes are demonstrably made without one.
/// `prepare_native_boxlite_environment` creates and starts the per-Goal base box
/// before `execute_native_goal_record` reaches `run_goal_parts` at all, and
/// again from `create_native_goal_assurance_runtime` on the verification effects
/// that take no lease by design. Counting held leases would not count either.
///
/// What bounds boxes today is the worker's shape: one Goal worker per daemon,
/// one Goal per execution tick, one BoxLite server on a port derived from that
/// process's pid — so two Goals could not even stand up two servers. Live boxes
/// are that one Goal's base box plus the boxes of the at most
/// `maximum_parallel_parts` Parts it advances at once. That is a real bound and
/// it is not this file's; choir-g3n.6 is precisely the change that removes it.
/// Bounding boxes for real needs two things this repository does not have yet:
/// a declared host memory and disk budget to derive a ceiling from, and a
/// decision about what the count is over — running boxes or created ones, per
/// BoxLite server or across the portfolio — which the one-server-per-Goal
/// topology has not settled. See choir-g3n.5 and choir-g3n.6.
///
/// One durable record per provider surface holds every lease currently held on
/// it. That shape is the whole point rather than an implementation detail: with
/// the held set in one record, "held count is below capacity" is decided and
/// committed in a single compare-and-set against that record's store version,
/// so two workers racing for the last slot cannot both win. A record per lease
/// would make the count a scan, and a scan followed by a write is exactly the
/// check-then-act that oversubscribes.
///
/// Nothing here does I/O. `plan_provider_lease_acquisition` and
/// `plan_provider_lease_release` return the record the caller should persist,
/// and `provider_lease_repository.mbt` performs the compare-and-set.

///|
/// Identity of one held provider slot.
///
/// Derived from the Goal, the Part, and the surface rather than minted, so a
/// worker that asks twice for the same Part's slot asks for the same lease and
/// the second ask is a no-op instead of a second slot.
pub(all) struct ProviderLeaseId(String) derive(Debug, Eq, ToJson, FromJson)

///|
/// One held provider slot.
///
/// Shaped after `@control.SandboxLease`: an id, the Take it was minted for, and
/// the generation that minted it. The generation is the whole reclamation
/// story — see `reclaim_provider_surface_leases`.
pub(all) struct ProviderLease {
  id : ProviderLeaseId
  take_id : @control.TakeId
  goal_id : @control.GoalId
  /// The daemon generation that minted this lease. A lease whose epoch is older
  /// than the current generation belonged to a worker that no longer exists.
  fencing_epoch : @control.FencingEpoch
  acquired_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Every lease currently held on one provider surface.
pub(all) struct ProviderSurfaceLeaseRecord {
  surface : @control.ProviderSurfaceId
  held : Array[ProviderLease]
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
} derive(Debug, Eq, ToJson, FromJson)

///|
/// What a worker is asking for.
pub(all) struct ProviderLeaseRequest {
  lease_id : ProviderLeaseId
  take_id : @control.TakeId
  goal_id : @control.GoalId
  /// This worker's generation. Also the fence its write commits under.
  fencing_epoch : @control.FencingEpoch
}

///|
/// The bounds the request is judged against.
///
/// `other_surfaces` carries the other surfaces' records rather than a
/// pre-computed total so that the same reclamation rule applies to them: a
/// count taken by the caller would count leases held by dead generations.
/// The per-surface bound is the exact one: it is decided and committed against
/// a single record's store version. The global ceiling spans records, so it is
/// judged against a read of the others and two surfaces committing at the same
/// instant can admit one over it. That is the price of one record per surface,
/// and it is the right price: the surface bound is the one a subscription
/// actually enforces, and it is the one that is never exceeded.
pub(all) struct ProviderLeaseCapacity {
  surface : Int
  global : Int?
  other_surfaces : Array[ProviderSurfaceLeaseRecord]
  /// How far ahead a refusal tells the caller to come back.
  deferral : Int64
}

///|
/// Which bound refused the request.
pub(all) enum ProviderLeaseLimit {
  /// This surface is serving as many Takes as it is configured to serve.
  ProviderSurfaceLimit
  /// Every surface together is at the configured global ceiling.
  ProviderGlobalLimit
} derive(Debug, Eq)

///|
/// The answer, which is never a bare "no".
///
/// A refusal names an instant, because a gate that can only say no leaves the
/// caller polling. `ProviderLeaseGranted` carries the record to persist; when
/// that record is identical to the one passed in, the lease was already held
/// and there is nothing to write.
pub(all) enum ProviderLeaseDecision {
  ProviderLeaseGranted(ProviderSurfaceLeaseRecord, ProviderLease)
  ProviderLeaseDeferredUntil(Int64, ProviderLeaseLimit)
} derive(Debug, Eq)

///|
/// The answer to a release.
///
/// `ProviderLeaseAlreadyReleased` means the record does not change, so the
/// caller writes nothing. That is what makes release idempotent: a second
/// release of the same lease cannot decrement the held count again, because it
/// produces no record to persist at all.
pub(all) enum ProviderLeaseReleaseDecision {
  ProviderLeaseReleased(ProviderSurfaceLeaseRecord)
  ProviderLeaseAlreadyReleased
} derive(Debug, Eq)

///|
fn provider_lease_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("provider lease: " + detail)
}

///|
/// The stable text one surface's durable record is keyed under.
///
/// Written out rather than derived from `to_json`, because this text is an
/// on-disk key: renaming the enum variant must not silently move every held
/// lease to an address nothing looks at.
pub fn provider_surface_lease_tag(
  surface : @control.ProviderSurfaceId,
) -> String {
  match surface {
    ClaudeSubscriptionCli => "claude-subscription-cli"
    CodexSubscriptionCli => "codex-subscription-cli"
  }
}

///|
/// How many Takes one surface may serve at once, under this configuration.
///
/// This exhaustive match is what keys `@types.ProviderCapacityPolicy` by
/// `@control.ProviderSurfaceId`: the policy record cannot name the enum
/// directly, because `Config` lives in `src/types` and `src/control` imports
/// `src/types`. A new provider surface does not compile until it is given a
/// bound here, and the bound it is given has to exist on the policy.
pub fn provider_surface_capacity(
  policy : @types.ProviderCapacityPolicy,
  surface : @control.ProviderSurfaceId,
) -> Int {
  match surface {
    ClaudeSubscriptionCli => policy.claude_subscription_cli
    CodexSubscriptionCli => policy.codex_subscription_cli
  }
}

///|
/// The lease one Part holds while it runs provider work on one surface.
///
/// Derived, not minted: the same Part asking again on the same surface asks for
/// the same slot, so re-entering the admission gate several times inside one
/// driver pass consumes one slot rather than one per call.
pub fn provider_lease_id(
  goal_id : @control.GoalId,
  part_id : @control.PartId,
  surface : @control.ProviderSurfaceId,
) -> ProviderLeaseId {
  ProviderLeaseId(
    "provider-lease-" +
    @storage.digest_text(
      @storage.artifact_digest(
        @utf8.encode(
          "choir.provider-lease.v1\u{00}" +
          goal_id.0 +
          "\u{00}" +
          part_id.0 +
          "\u{00}" +
          provider_surface_lease_tag(surface),
        ),
      ),
    ),
  )
}

///|
/// The lease one Goal assurance attempt holds while its audit session runs.
///
/// Derived like `provider_lease_id`, and for the same reason, but from the
/// audit Take instead of a Part: a Goal audit has no Part to key on. Every tick
/// that advances the same assurance attempt re-derives this same id, so asking
/// again returns the slot already held rather than taking a second one. A
/// replanned attempt mints a fresh audit Take and therefore a different lease,
/// which is right — it is a different session.
///
/// The domain prefix differs from the Part one, so a Goal and one of its Parts
/// can never collide on a single slot.
pub fn goal_assurance_provider_lease_id(
  goal_id : @control.GoalId,
  audit_take_id : @control.TakeId,
  surface : @control.ProviderSurfaceId,
) -> ProviderLeaseId {
  ProviderLeaseId(
    "provider-lease-" +
    @storage.digest_text(
      @storage.artifact_digest(
        @utf8.encode(
          "choir.goal-assurance-provider-lease.v1\u{00}" +
          goal_id.0 +
          "\u{00}" +
          audit_take_id.0 +
          "\u{00}" +
          provider_surface_lease_tag(surface),
        ),
      ),
    ),
  )
}

///|
/// The record a surface starts from when nothing has ever been held on it.
///
/// Version zero, which no stored record ever has: it is the base a first
/// acquisition plans against, so the record that acquisition produces is
/// version one and its compare-and-set expects no prior version at all.
pub fn empty_provider_surface_lease_record(
  surface : @control.ProviderSurfaceId,
  fencing_epoch : @control.FencingEpoch,
) -> ProviderSurfaceLeaseRecord {
  { surface, held: [], durable_version: 0, fencing_epoch }
}

///|
/// How long a refused caller waits before asking again.
///
/// A held lease has no expiry to wait for — it is released when the work ends,
/// or reclaimed when the generation that took it dies — so there is no instant
/// in the record to name. This is the capped interval that turns a refusal into
/// a scheduled wake rather than a spin.
pub fn provider_lease_deferral_seconds() -> Int64 {
  5L
}

///|
/// Drop every lease minted by a generation that no longer exists.
///
/// This is the only reclamation there is: no TTL, no heartbeat. A worker that
/// died still holds its slot in the record, and every lease from it is
/// recognizable by its epoch alone. Because it runs on read, restart
/// reconciliation is not separate code — the first acquisition after a restart
/// reclaims what the crash left.
///
/// That rests on one fact outside this package: every worker process runs under
/// its own generation. `conductor_start_goal_worker` mints a strictly greater
/// epoch under `BEGIN IMMEDIATE` before each spawn — including the supervisor's
/// restart of a crashed worker — and the worker only ever observes. Move the
/// mint back to daemon startup and a restarted worker inherits its predecessor's
/// epoch, which makes the two indistinguishable here and strands the dead
/// worker's slots until the daemon itself restarts.
///
/// A lease minted by a *newer* generation is kept. It belongs to a worker that
/// superseded this one, and this process has no authority to release it; the
/// state store's own stale-fence gate would refuse the write anyway.
pub fn reclaim_provider_surface_leases(
  held : Array[ProviderLease],
  fencing_epoch : @control.FencingEpoch,
) -> Array[ProviderLease] {
  held.filter(fn(lease) { lease.fencing_epoch.0 >= fencing_epoch.0 })
}

///|
/// Decide whether one worker may hold a provider slot.
///
/// Pure. The returned record is what the caller compare-and-sets; when it is
/// the record that came in, the lease was already held and nothing is written.
pub fn plan_provider_lease_acquisition(
  record : ProviderSurfaceLeaseRecord,
  request : ProviderLeaseRequest,
  capacity : ProviderLeaseCapacity,
  now : Int64,
) -> ProviderLeaseDecision {
  let live = reclaim_provider_surface_leases(record.held, request.fencing_epoch)
  let next_record = fn(held : Array[ProviderLease]) {
    if held == record.held && record.fencing_epoch == request.fencing_epoch {
      record
    } else {
      {
        surface: record.surface,
        held,
        durable_version: record.durable_version + 1,
        fencing_epoch: request.fencing_epoch,
      }
    }
  }
  for lease in live {
    if lease.id == request.lease_id {
      return ProviderLeaseGranted(next_record(live), lease)
    }
  }
  if live.length() >= capacity.surface {
    return ProviderLeaseDeferredUntil(
      now + capacity.deferral,
      ProviderSurfaceLimit,
    )
  }
  match capacity.global {
    Some(ceiling) => {
      let mut elsewhere = 0
      for other in capacity.other_surfaces {
        if other.surface != record.surface {
          elsewhere = elsewhere +
            reclaim_provider_surface_leases(other.held, request.fencing_epoch).length()
        }
      }
      if live.length() + elsewhere >= ceiling {
        return ProviderLeaseDeferredUntil(
          now + capacity.deferral,
          ProviderGlobalLimit,
        )
      }
    }
    None => ()
  }
  let lease : ProviderLease = {
    id: request.lease_id,
    take_id: request.take_id,
    goal_id: request.goal_id,
    fencing_epoch: request.fencing_epoch,
    acquired_at: now,
  }
  ProviderLeaseGranted(next_record([..live, lease]), lease)
}

///|
/// Give one provider slot back.
///
/// Releasing a lease that is absent — already released, or reclaimed with its
/// generation — succeeds and produces no record, so the held count cannot be
/// decremented twice by a caller that retries.
pub fn plan_provider_lease_release(
  record : ProviderSurfaceLeaseRecord,
  lease_id : ProviderLeaseId,
  fencing_epoch : @control.FencingEpoch,
) -> ProviderLeaseReleaseDecision {
  let remaining = reclaim_provider_surface_leases(record.held, fencing_epoch).filter(fn(
      lease,
    ) {
      lease.id != lease_id
    },
  )
  if remaining == record.held && record.fencing_epoch == fencing_epoch {
    return ProviderLeaseAlreadyReleased
  }
  ProviderLeaseReleased({
    surface: record.surface,
    held: remaining,
    durable_version: record.durable_version + 1,
    fencing_epoch,
  })
}

///|
pub fn provider_surface_lease_record_bytes(
  record : ProviderSurfaceLeaseRecord,
) -> Bytes {
  @utf8.encode(record.to_json().stringify(indent=0))
}

///|
pub fn decode_provider_surface_lease_record(
  content : Bytes,
) -> Result[ProviderSurfaceLeaseRecord, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(provider_lease_error("record is not valid JSON"))
  }
  let record : ProviderSurfaceLeaseRecord = @json.from_json(json) catch {
    _ => return Err(provider_lease_error("record has the wrong schema"))
  }
  if record.durable_version <= 0 || record.fencing_epoch.0 <= 0L {
    return Err(provider_lease_error("record identity is invalid"))
  }
  let seen : Array[ProviderLeaseId] = []
  for lease in record.held {
    if lease.id.0 == "" ||
      lease.take_id.0 == "" ||
      lease.goal_id.0 == "" ||
      lease.fencing_epoch.0 <= 0L ||
      lease.acquired_at < 0L ||
      seen.contains(lease.id) {
      return Err(provider_lease_error("held lease is invalid"))
    }
    seen.push(lease.id)
  }
  Ok(record)
}

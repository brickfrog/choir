///| What the portfolio's provider surfaces are doing, for the reader of a Goal.
///
/// `provider_lease.mbt` decides who may hold a surface; nothing there is
/// visible to an operator. A surface at its bound is indistinguishable from a
/// slow Take: both look like a Goal that is not moving. This projects the same
/// durable lease records the gate commits against, so "Claude is full and
/// three Parts are waiting on it" is read rather than guessed.
///
/// Nothing here counts anything twice. The held figure is the length of the
/// surface's own held set after reclamation, which is the exact quantity
/// `plan_provider_lease_acquisition` compares against the bound, and the
/// deferral instant is the one the gate named — carried through
/// `ProviderSurfaceTickReport`, the same observation the daemon paces its
/// sleep with.

///|
/// One provider surface's admission state as of the report that carries it.
pub(all) struct ProviderSurfaceCapacityStatus {
  surface : @control.ProviderSurfaceId
  /// Slots held on this surface right now, counted after leases minted by a
  /// generation that no longer exists are reclaimed — the same reclamation the
  /// gate applies, so a crashed worker's slots are not reported as pressure.
  held : Int
  /// How many Takes this configuration lets the surface serve at once.
  capacity : Int
  /// The instant the admission gate named when it refused this surface during
  /// the tick this report describes. `None` when the tick admitted work on it
  /// or never asked for it.
  deferred_until : Int64?
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Everything the capacity projection is derived from.
///
/// A record rather than a computed summary, because the summary is the thing
/// under test: handed a pre-counted "held: 4" this projection would report
/// whatever it was told, and a reader could not tell a real bound from an
/// invented one.
pub(all) struct ProviderCapacityObservation {
  /// Every surface's durable held set, as read from the control store.
  lease_records : Array[ProviderSurfaceLeaseRecord]
  /// What the admission gate answered per surface during the tick this report
  /// describes. Empty in a process that runs no tick, which reports no
  /// deferral rather than inventing one.
  tick_reports : Array[ProviderSurfaceTickReport]
  policy : @types.ProviderCapacityPolicy
  /// The generation reading the records. Leases older than it belong to
  /// workers that no longer exist and are not held.
  fencing_epoch : @control.FencingEpoch
}

///|
/// Whether this surface can serve another Take right now.
///
/// One notion of pressure for every reader: the count that decides a Part is
/// waiting is the same one that decides the statusline says anything at all. A
/// surface below its bound that refused nothing has no pressure, and a zero is
/// noise rather than information.
///
/// The deferral matters on its own because the surface bound is not the only
/// bound: a refusal by the global execution ceiling leaves this surface below
/// its own capacity and still unable to serve.
fn provider_surface_is_pressured(
  status : ProviderSurfaceCapacityStatus,
) -> Bool {
  status.held >= status.capacity || status.deferred_until is Some(_)
}

///|
/// Project every scheduled surface's admission state.
///
/// Every surface appears, including the quiet ones: a surface missing from the
/// projection and a surface holding nothing would otherwise be the same
/// reading, and the caller decides which are worth showing.
fn provider_surface_capacity_statuses(
  observation : ProviderCapacityObservation,
) -> Array[ProviderSurfaceCapacityStatus] {
  scheduled_provider_surfaces().map(fn(surface) {
    let mut held = 0
    for record in observation.lease_records {
      if record.surface == surface {
        held = held +
          reclaim_provider_surface_leases(
            record.held,
            observation.fencing_epoch,
          ).length()
      }
    }
    {
      surface,
      held,
      capacity: provider_surface_capacity(observation.policy, surface),
      deferred_until: provider_surface_deferred_until(
        observation.tick_reports,
        surface,
      ),
    }
  })
}

///|
/// The surface this Part holds a slot on right now, if any.
///
/// A Part's lease is derived from the Goal, the Part, and the surface, and is
/// held for exactly as long as the pass that dispatches its provider work. So
/// a lease in the durable record says this Part is running rather than
/// waiting, which is the difference between a full surface serving this Goal
/// and a full surface starving it.
///
/// A slot taken for the Goal's own audit session is keyed on that Take rather
/// than on a Part, so it counts toward `held` — the surface is serving it —
/// and is claimed by no Part here, which is what it is.
fn part_leased_provider_surface(
  observation : ProviderCapacityObservation,
  goal_id : @control.GoalId,
  part_id : @control.PartId,
) -> @control.ProviderSurfaceId? {
  for record in observation.lease_records {
    let lease_id = provider_lease_id(goal_id, part_id, record.surface)
    for
      lease in reclaim_provider_surface_leases(
        record.held,
        observation.fencing_epoch,
      ) {
      if lease.id == lease_id {
        return Some(record.surface)
      }
    }
  }
  None
}
